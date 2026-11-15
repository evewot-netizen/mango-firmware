"""Generate a reviewable self-contained upgrade of the preparation scripts."""
from pathlib import Path
root=Path(__file__).resolve().parent
files=[('worker.sh','/etc/mango-ha-update-worker.sh'),('service','/etc/init.d/mango-ha-update-job'),('dispatch.sh','/etc/mango-ha-update.sh'),('install.sh','/etc/mango-ha-update-install.sh')]
s='''#!/bin/sh
set -eu
umask 077
test -f /lib/functions/procd.sh
command -v flock >/dev/null
test -f /etc/mango-ha-update.sh
test -f /etc/mango-ha-update-worker.sh
test -f /etc/init.d/mango-ha-update-job
test ! -e /etc/mango-ha-update-install.sh
test ! -e /etc/mango-ha-update-install-enabled
case "$(cat /tmp/mango-ha-update-job/state 2>/dev/null || true)" in
    QUEUED|PREPARING|READY|INSTALL_QUEUED|INSTALLING) echo 'Active job; aborting.' >&2; exit 1;;
esac
save="/root/vor-ha-install-stufe-$(date +%Y%m%d-%H%M%S)"
mkdir "$save"
cp -p /etc/mango-ha-update.sh "$save/dispatch"
cp -p /etc/mango-ha-update-worker.sh "$save/worker"
cp -p /etc/init.d/mango-ha-update-job "$save/service"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Sicherung: $save"
work=$(mktemp -d /tmp/mango-install-stufe.XXXXXX)
trap 'rm -rf "$work"' EXIT
'''
for i,(name,target) in enumerate(files):
    s+=f'cat > "$work/{name}" <<\'MANGO_FILE_{i}\'\n'+(root/'router'/name).read_text()+f'MANGO_FILE_{i}\n/bin/sh -n "$work/{name}"\n'
s+='/etc/init.d/mango-ha-update-job stop >/dev/null 2>&1 || true\n'
for name,target in files:
    s+=f'cp "$work/{name}" "{target}"\nchmod 700 "{target}"\n'
s+='''for file in /etc/mango-ha-update.sh /etc/mango-ha-update-worker.sh /etc/mango-ha-update-install.sh /etc/init.d/mango-ha-update-job /etc/mango-ha-update-last; do
    grep -Fxq "$file" /etc/sysupgrade.conf || printf '%s\\n' "$file" >> /etc/sysupgrade.conf
done
# Do not preserve the activation flag across firmware upgrades. Re-enabling
# requires the Pi's successful post-update checks and an explicit later step.
/etc/init.d/mango-ha-update-job disable
if SSH_ORIGINAL_COMMAND="install aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" /bin/sh /etc/mango-ha-update.sh; then
    echo 'Unexpected install access!' >&2
    exit 1
fi
SSH_ORIGINAL_COMMAND=job /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: Installationsstufe vorbereitet. Aktivierung bleibt gesperrt.'
'''
(root/'install-router-control.sh').write_text(s)
