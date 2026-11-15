#!/bin/sh
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
printf '%s  %s\n' \
    0d55007d2aab29007efb94169231b2129acae0bb29e629c75da96cc91c32ca2a /etc/mango-ha-update-install.sh \
    4b7a6c176dfb2ae79c00c98f8b7186d9e2fa6968b7a8b80daa48143aa4a3c28d /etc/mango-ha-update-worker.sh \
    d6e292dd55392c38ab2535cfa0bb148845b283a3122527e1a08681924946d95c /etc/mango-ha-update.sh \
    d989f0837ad73c6ff1a46ba4d4daafc09c0258d11eb84a185aad8be4ade1eb1e /usr/lib/autoupdater/upgrade.d/10stop-network | sha256sum -c -
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
work=$(mktemp -d /tmp/mango-networkfix.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/install.sh" <<'MANGO_INSTALL'
#!/bin/sh
# Invoked only by procd after an explicit, hash-bound request from the Pi.
set -eu
umask 077
state=/tmp/mango-ha-update-job
exec 9> /var/lock/mango-ha-update-job.lock
flock -n 9 || exit 1
exec >> "$state/log" 2>&1
started_hooks=0
handed_off=0
write_state() {
    printf '%s\n' "$1" > "$state/state.new"
    mv "$state/state.new" "$state/state"
}
fail_cleanup() {
    result=$?
    if test "$handed_off" != 1; then
        echo "Installation aborted before flash handoff (exit $result)."
        write_state ERROR
        if test "$started_hooks" = 1; then
            for hook in /usr/lib/autoupdater/abort.d/*; do
                test -f "$hook" && test -x "$hook" || continue
                "$hook" 8>&- 9>&- || true
            done
        fi
    fi
}
trap fail_cleanup EXIT
trap 'exit 1' HUP INT TERM
valid_hash() {
    test "${#1}" = 64 || return 1
    case "$1" in *[!0-9a-f]*) return 1;; esac
}
test "$(cat /etc/mango-ha-update-install-enabled 2>/dev/null)" = enabled
test "$(cat "$state/state")" = INSTALL_QUEUED
test "$(uci -q get autoupdater.settings.enabled)" = 0
test "$(uci -q get autoupdater.settings.branch)" = mango
test "$(uci -q get autoupdater.mango.good_signatures)" = 1
image_hash=$(cat "$state/request-image-sha256")
backup_hash=$(cat "$state/request-backup-sha256")
valid_hash "$image_hash"
valid_hash "$backup_hash"
test "$image_hash" = "$(cat "$state/sha256")"
test -s "$state/firmware.bin"
test ! -L "$state/firmware.bin"
test "$image_hash" = "$(sha256sum "$state/firmware.bin" | awk '{print $1}')"
test "$(cat /lib/gluon/release)" = "$(cat "$state/old-version")"
created=$(cat "$state/prepared-at")
case "$created" in ''|*[!0-9]*) exit 1;; esac
age=$(($(date +%s) - created))
test "$age" -ge 0 && test "$age" -le 3600
# Hold the native updater's lock through the flash handoff.
exec 8> /var/lock/autoupdater.lock
flock -n 8
# This exact upstream hook deletes bat0 unconditionally after stopping netifd.
# netifd may have removed it already. Handle only that known hook idempotently;
# retain strict failure handling for other hooks and for real deletion errors.
network_hook=/usr/lib/autoupdater/upgrade.d/10stop-network
if test -f "$network_hook"; then
    test "$(sha256sum "$network_hook" | awk '{print $1}')" = d989f0837ad73c6ff1a46ba4d4daafc09c0258d11eb84a185aad8be4ade1eb1e || {
        echo 'Unknown network-stop hook; refusing to substitute it.'
        exit 1
    }
fi
# No --force, no -n and no compatibility override: keep configuration and
# refuse an incompatible image even if the earlier native dry-run allowed it.
/sbin/sysupgrade --test "$state/firmware.bin" 8>&- 9>&-
echo 'Image compatibility check passed.'
# This receipt is an audit record. The Pi must verify the backup before sending
# its hash; a hash alone cannot prove that a remote archive was safely stored.
{
    printf 'IMAGE_SHA256=%s\n' "$image_hash"
    printf 'BACKUP_SHA256=%s\n' "$backup_hash"
    printf 'OLD_VERSION=%s\n' "$(cat "$state/old-version")"
    printf 'STARTED_AT=%s\n' "$(date +%s)"
} > /etc/mango-ha-update-last.new
mv /etc/mango-ha-update-last.new /etc/mango-ha-update-last
write_state INSTALLING
started_hooks=1
for dir in /usr/lib/autoupdater/download.d /usr/lib/autoupdater/upgrade.d; do
    for hook in "$dir"/*; do
        test -f "$hook" && test -x "$hook" || continue
        echo "Running upgrade hook: $hook"
        if test "$hook" = "$network_hook"; then
            (
                . /lib/gluon/autoupdater/lib.sh
                wifi down
                sleep 1
                stop network
                if test -e /sys/class/net/bat0; then
                    ip link del bat0
                else
                    echo 'bat0 already removed by network shutdown.'
                fi
            ) 8>&- 9>&-
        else
            "$hook" 8>&- 9>&-
        fi
    done
done
sync
# No respawn and no boot enable: never repeat an installation automatically.
handed_off=1
echo 'Handing verified image to sysupgrade.'
exec /sbin/sysupgrade "$state/firmware.bin"
MANGO_INSTALL
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
grep -Fxq /etc/mango-ha-update-install.sh /etc/sysupgrade.conf || printf '%s\n' /etc/mango-ha-update-install.sh >> /etc/sysupgrade.conf
# Start a new signed preparation; never reuse an aged candidate or receipt.
rm -f "$state/firmware.bin" "$state/sha256" "$state/prepared-at" \
    "$state/request-image-sha256" "$state/request-backup-sha256"
printf '%s\n' IDLE > "$state/state.new"
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
