#!/bin/sh
set -eu
umask 077
test -f /lib/functions/procd.sh
command -v flock >/dev/null
test -f /etc/mango-ha-update.sh
test -f /etc/mango-ha-update-worker.sh
test -f /etc/init.d/mango-ha-update-job
grep -Fq 'selftest)' /etc/mango-ha-update-worker.sh || { echo 'Expected selftest worker not found; aborting.' >&2; exit 1; }
save="/root/vor-ha-update-job-$(date +%Y%m%d-%H%M%S)"
mkdir "$save"
cp -p /etc/mango-ha-update.sh "$save/dispatch"
cp -p /etc/mango-ha-update-worker.sh "$save/worker"
cp -p /etc/init.d/mango-ha-update-job "$save/service"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Sicherung: $save"
work=$(mktemp -d /tmp/mango-job-install.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/worker.sh" <<'MANGO_FILE_0'
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
if ! /usr/sbin/autoupdater --branch mango --force --no-action > "$state/check.log" 2>&1; then
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
MANGO_FILE_0
/bin/sh -n "$work/worker.sh"
cat > "$work/service" <<'MANGO_FILE_1'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/mango-ha-update-worker.sh
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
MANGO_FILE_1
/bin/sh -n "$work/service"
cat > "$work/dispatch.sh" <<'MANGO_FILE_2'
#!/bin/sh
set -eu
umask 077
state=/tmp/mango-ha-update-job
case "${SSH_ORIGINAL_COMMAND:-}" in
    status)
        echo '--- Installierte Firmware ---'
        cat /lib/gluon/release
        echo '--- Update-Kanal ---'
        uci -q get autoupdater.settings.branch
        echo '--- Selbststaendige Updates aktiviert ---'
        uci -q get autoupdater.settings.enabled
        ;;
    prepare)
        mkdir -p "$state"
        chmod 700 "$state"
        exec 7> /var/lock/mango-ha-update-request.lock
        flock -n 7
        current=$(cat "$state/state" 2>/dev/null || true)
        case "$current" in
            QUEUED|PREPARING|READY)
                echo "STATE=$current"
                echo 'Existing job retained; no second job started.'
                exit 0
                ;;
        esac
        exec 9> /var/lock/mango-ha-update-job.lock
        flock -n 9
        printf '%s\n' QUEUED > "$state/state"
        flock -u 9
        exec 9>&-
        if ! /etc/init.d/mango-ha-update-job restart; then
            printf '%s\n' ERROR > "$state/state"
            exit 1
        fi
        echo 'STATE=QUEUED'
        ;;
    job)
        current=$(cat "$state/state" 2>/dev/null || printf IDLE)
        printf 'STATE=%s\n' "$current"
        if test "$current" = READY; then
            printf 'SHA256=%s\n' "$(cat "$state/sha256")"
        fi
        if test -f "$state/log"; then
            tail -n 15 "$state/log"
        fi
        ;;
    check)
        # Retain compatibility with the earlier manual preparation script.
        test "$(uci -q get autoupdater.settings.enabled)" = 0
        test "$(uci -q get autoupdater.settings.branch)" = mango
        test "$(uci -q get autoupdater.mango.good_signatures)" = 1
        exec 9> /var/lock/mango-ha-update-job.lock
        flock -n 9
        case "$(cat "$state/state" 2>/dev/null || true)" in
            QUEUED|PREPARING|READY) echo 'Background job already present.' >&2; exit 1;;
        esac
        /usr/sbin/autoupdater --branch mango --force --no-action
        ;;
    *)
        echo 'Allowed commands: status, check, prepare, job. Installation is not enabled.' >&2
        exit 1
        ;;
esac
MANGO_FILE_2
/bin/sh -n "$work/dispatch.sh"
/etc/init.d/mango-ha-update-job stop
cp "$work/worker.sh" "/etc/mango-ha-update-worker.sh"
chmod 700 "/etc/mango-ha-update-worker.sh"
cp "$work/service" "/etc/init.d/mango-ha-update-job"
chmod 700 "/etc/init.d/mango-ha-update-job"
cp "$work/dispatch.sh" "/etc/mango-ha-update.sh"
chmod 700 "/etc/mango-ha-update.sh"
for file in /etc/mango-ha-update.sh /etc/mango-ha-update-worker.sh /etc/init.d/mango-ha-update-job; do
    grep -Fxq "$file" /etc/sysupgrade.conf || printf '%s\n' "$file" >> /etc/sysupgrade.conf
done
/etc/init.d/mango-ha-update-job disable
SSH_ORIGINAL_COMMAND=status /bin/sh /etc/mango-ha-update.sh
if SSH_ORIGINAL_COMMAND=install /bin/sh /etc/mango-ha-update.sh; then
    echo 'Unexpected install access!' >&2
    exit 1
fi
echo 'ERFOLG: Hintergrundpruefung eingerichtet. Installation bleibt gesperrt.'
