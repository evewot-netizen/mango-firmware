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
