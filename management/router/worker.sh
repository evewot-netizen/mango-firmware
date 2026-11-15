#!/bin/sh
# Only preparation is implemented here. This worker cannot flash firmware.
set -eu
umask 077
state=/tmp/mango-ha-update-job
mkdir -p "$state"
chmod 700 "$state"
exec 9> /var/lock/mango-ha-update-job.lock
flock -n 9 || exit 1
finished=0
write_state() {
    printf '%s\n' "$1" > "$state/state.new"
    mv "$state/state.new" "$state/state"
}
cleanup() {
    if test "$finished" != 1; then
        rm -f "$state/firmware.bin" "$state/sha256"
        write_state ERROR
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
exec > "$state/log" 2>&1
write_state PREPARING

test "$(uci -q get autoupdater.settings.enabled)" = 0
test "$(uci -q get autoupdater.settings.branch)" = mango
test "$(uci -q get autoupdater.mango.good_signatures)" = 1
# Use exactly the configured project mirror; never accept a caller-supplied URL.
test "$(uci -q get autoupdater.mango.mirror)" = 'https://evewot-netizen.github.io/mango-firmware/updates/'
rm -f "$state/firmware.bin" "$state/sha256"
cat /lib/gluon/release > "$state/old-version"
# Do not remove an unrelated image left by a manual operator.
if test -e /tmp/firmware.bin; then
    echo 'Existing /tmp/firmware.bin: refusing to overwrite it.'
    exit 1
fi
# Keep the lock in this worker; restarted daemons must not inherit it.
if ! /usr/sbin/autoupdater --branch mango --force --no-action 9>&- > "$state/check.log" 2>&1; then
    cat "$state/check.log"
    exit 1
fi
cat "$state/check.log"
none=0
ready=0
grep -Fxq 'No new firmware available.' "$state/check.log" && none=1
grep -Fxq 'autoupdater: info: Aborting successful upgrade because simulation was requested.' "$state/check.log" && ready=1
if test "$none:$ready" = 1:0; then
    write_state NO_UPDATE
elif test "$none:$ready" = 0:1; then
    # The upstream updater has verified manifest signatures, image hash and
    # compatibility. Take its lock before claiming the downloaded file.
    exec 8> /var/lock/autoupdater.lock
    flock -n 8
    test -s /tmp/firmware.bin
    test ! -L /tmp/firmware.bin
    mv /tmp/firmware.bin "$state/firmware.bin"
    sha256sum "$state/firmware.bin" | awk '{print $1}' > "$state/sha256"
    date +%s > "$state/prepared-at"
    write_state READY
else
    echo 'Ambiguous updater output; refusing to mark firmware ready.'
    exit 1
fi
finished=1
