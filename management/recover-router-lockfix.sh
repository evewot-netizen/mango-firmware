#!/bin/sh
# One-time recovery of the observed, never-accepted Test7 install request.
set -eu
umask 077
state=/tmp/mango-ha-update-job
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test6
test "$(cat /proc/sys/kernel/random/boot_id)" = 89f96f09-fb52-4881-ae04-37a186065674
test "$(cat /etc/mango-ha-update-install-enabled)" = enabled
printf '%s  %s\n' \
    4b7a6c176dfb2ae79c00c98f8b7186d9e2fa6968b7a8b80daa48143aa4a3c28d /etc/mango-ha-update-worker.sh \
    0d55007d2aab29007efb94169231b2129acae0bb29e629c75da96cc91c32ca2a /etc/mango-ha-update-install.sh \
    d6e292dd55392c38ab2535cfa0bb148845b283a3122527e1a08681924946d95c /etc/mango-ha-update.sh | sha256sum -c -
exec 7> /var/lock/mango-ha-update-request.lock
flock -n 7
exec 9> /var/lock/mango-ha-update-job.lock
flock -n 9
exec 8> /var/lock/autoupdater.lock
flock -n 8
test "$(cat "$state/state")" = READY
test ! -e "$state/request-image-sha256"
test ! -e "$state/request-backup-sha256"
test "$(cat "$state/sha256")" = d71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c
test ! -e /tmp/firmware.bin
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
save=$(mktemp -d /root/vor-ha-neupruefung.XXXXXX)
for name in state sha256 prepared-at old-version log check.log; do
    cp -p "$state/$name" "$save/$name"
done
echo "Bisheriges Pruefprotokoll gesichert: $save"
/etc/init.d/mango-ha-update-job stop 7>&- 8>&- 9>&-
# Discard only this uninstalled temporary candidate; keep all configuration.
rm -f "$state/firmware.bin" "$state/sha256" "$state/prepared-at"
printf '%s\n' IDLE > "$state/state.new"
mv "$state/state.new" "$state/state"
flock -u 8
exec 8>&-
flock -u 9
exec 9>&-
flock -u 7
exec 7>&-
SSH_ORIGINAL_COMMAND=prepare /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: Neue Firmware-Pruefung gestartet. Noch keine Installation.'
