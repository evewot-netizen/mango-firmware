"""One-time guarded repair of the observed Test6 pre-flash hook failure."""
from pathlib import Path

root = Path(__file__).resolve().parent
script = '''#!/bin/sh
set -eu
umask 077
state=/tmp/mango-ha-update-job
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test6
test "$(cat /proc/sys/kernel/random/boot_id)" = 89f96f09-fb52-4881-ae04-37a186065674
test "$(cat /etc/mango-ha-update-install-enabled)" = enabled
exec 7> /var/lock/mango-ha-update-request.lock
flock -n 7
exec 9> /var/lock/mango-ha-update-job.lock
flock -n 9
exec 8> /var/lock/autoupdater.lock
flock -n 8
test "$(cat "$state/state")" = ERROR
test "$(cat "$state/request-image-sha256")" = d71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c
test "$(cat "$state/request-backup-sha256")" = c0f4e36099c496377055cea429cd08d55337e2910ddf76ca68607a2f53810192
grep -Fq "ip: can't find device 'bat0'" "$state/log"
test ! -e /tmp/firmware.bin
echo '--- Bekannte Skriptversionen pruefen ---'
printf '%s  %s\\n' \\
    0d55007d2aab29007efb94169231b2129acae0bb29e629c75da96cc91c32ca2a /etc/mango-ha-update-install.sh \\
    4b7a6c176dfb2ae79c00c98f8b7186d9e2fa6968b7a8b80daa48143aa4a3c28d /etc/mango-ha-update-worker.sh \\
    d6e292dd55392c38ab2535cfa0bb148845b283a3122527e1a08681924946d95c /etc/mango-ha-update.sh \\
    d989f0837ad73c6ff1a46ba4d4daafc09c0258d11eb84a185aad8be4ade1eb1e /usr/lib/autoupdater/upgrade.d/10stop-network | sha256sum -c -
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
work=$(mktemp -d /tmp/mango-networkfix.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/install.sh" <<'MANGO_INSTALL'
'''
script += (root/'router/install.sh').read_text()
script += '''MANGO_INSTALL
/bin/sh -n "$work/install.sh"
save=$(mktemp -d /root/vor-ha-networkfix.XXXXXX)
cp -p /etc/mango-ha-update-install.sh "$save/install.sh"
cp -p /etc/mango-ha-update-last "$save/last-receipt"
for name in state sha256 prepared-at old-version log check.log request-image-sha256 request-backup-sha256; do
    cp -p "$state/$name" "$save/$name"
done
echo "Sicherung und bisheriges Fehlerprotokoll: $save"
/etc/init.d/mango-ha-update-job stop 7>&- 8>&- 9>&-
cp "$work/install.sh" /etc/mango-ha-update-install.sh.new
chmod 700 /etc/mango-ha-update-install.sh.new
mv /etc/mango-ha-update-install.sh.new /etc/mango-ha-update-install.sh
grep -Fxq /etc/mango-ha-update-install.sh /etc/sysupgrade.conf || printf '%s\\n' /etc/mango-ha-update-install.sh >> /etc/sysupgrade.conf
# Start a new signed preparation; never reuse an aged candidate or receipt.
rm -f "$state/firmware.bin" "$state/sha256" "$state/prepared-at" \\
    "$state/request-image-sha256" "$state/request-backup-sha256"
printf '%s\\n' IDLE > "$state/state.new"
mv "$state/state.new" "$state/state"
flock -u 8
exec 8>&-
flock -u 9
exec 9>&-
flock -u 7
exec 7>&-
SSH_ORIGINAL_COMMAND=prepare /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: Netzwerk-Stopp korrigiert und neue Firmware-Pruefung gestartet.'
echo 'Noch keine Installation. Die Pi-Wiederaufnahme folgt separat.'
'''
(root/'install-router-networkfix.sh').write_text(script)
