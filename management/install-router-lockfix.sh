#!/bin/sh
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
printf '%s  %s\n' '8d7daf594581912e9aad4dc8fa8ed0d7c6231cbcaa3ca766e348c93c3d1a447e' '/etc/mango-ha-update-worker.sh' | sha256sum -c -
printf '%s  %s\n' '203c0936f68db91f9f7f2a74fc4622a6e093ae862de4a3cba5672fa836b00eff' '/etc/mango-ha-update-install.sh' | sha256sum -c -
printf '%s  %s\n' '93bf95bfa681dd46a12303036718f62e84b4b9e29b47315017ffc5f20e8c6a9f' '/etc/mango-ha-update.sh' | sha256sum -c -
work=$(mktemp -d /tmp/mango-lockfix.XXXXXX)
restart_needed=0
cleanup() {
    if test "$restart_needed" = 1; then
        /etc/init.d/sse-multiplexd start 7>&- 9>&- || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/worker.sh" <<'LOCKFIX_0'
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
LOCKFIX_0
/bin/sh -n "$work/worker.sh"
cat > "$work/install.sh" <<'LOCKFIX_1'
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
    if test "$handed_off" != 1; then
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
# No --force, no -n and no compatibility override: keep configuration and
# refuse an incompatible image even if the earlier native dry-run allowed it.
/sbin/sysupgrade --test "$state/firmware.bin" 8>&- 9>&-
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
        "$hook" 8>&- 9>&-
    done
done
sync
# No respawn and no boot enable: never repeat an installation automatically.
handed_off=1
exec /sbin/sysupgrade "$state/firmware.bin"
LOCKFIX_1
/bin/sh -n "$work/install.sh"
cat > "$work/dispatch.sh" <<'LOCKFIX_2'
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
    health)
        health_fail() { echo "HEALTH_ERROR=$*" >&2; exit 1; }
        test "$(uci -q get network.wgverwaltung.tunlink)" = wan || health_fail 'WireGuard-Uplink'
        test -x /etc/mango-fritz-adressen.sh || health_fail 'Adresspruefung fehlt'
        /etc/init.d/cron status >/dev/null 2>&1 || health_fail 'Cron laeuft nicht'
        handshake=$(wg show wgverwaltung latest-handshakes | awk 'NR==1 {print $2}')
        case "$handshake" in ''|*[!0-9]*) health_fail 'WireGuard-Handshake fehlt';; esac
        age=$(($(date +%s) - handshake))
        test "$handshake" -gt 0 && test "$age" -ge 0 && test "$age" -le 180 || health_fail 'WireGuard-Handshake veraltet'
        for family in 4 6; do
            rule="firewall.mango_fritz_v$family"
            test "$(uci -q get "$rule.target")" = REJECT || health_fail "$rule Ziel"
            addresses=$(uci -q get "$rule.dest_ip") || health_fail "$rule Adressen"
            test -n "$addresses" || health_fail "$rule leer"
            if test "$family" = 4; then tool=iptables; else tool=ip6tables; fi
            for address in $addresses; do
                for port in 80 443 49000 49443; do
                    "$tool" -C zone_wan_output -d "$address" -p tcp -m tcp --dport "$port" \
                        -m comment --comment "!fw3: Mango-Fritz-v$family" \
                        -j zone_wan_dest_REJECT 2>/dev/null || health_fail "IPv$family $address Port $port nicht gesperrt"
                done
            done
        done
        echo 'HEALTH=OK'
        ;;
    prepare)
        mkdir -p "$state"
        chmod 700 "$state"
        exec 7> /var/lock/mango-ha-update-request.lock
        flock -n 7
        current=$(cat "$state/state" 2>/dev/null || true)
        case "$current" in
            QUEUED|PREPARING|READY|INSTALL_QUEUED|INSTALLING)
                echo "STATE=$current"
                echo 'Existing job retained; no second job started.'
                exit 0
                ;;
        esac
        exec 9> /var/lock/mango-ha-update-job.lock
        flock -n 9
        printf '%s\n' prepare > "$state/mode"
        printf '%s\n' QUEUED > "$state/state"
        flock -u 9
        exec 9>&-
        /etc/init.d/mango-ha-update-job stop 7>&- >/dev/null 2>&1 || true
        if ! /etc/init.d/mango-ha-update-job start 7>&-; then
            printf '%s\n' ERROR > "$state/state"
            exit 1
        fi
        echo 'STATE=QUEUED'
        ;;
    install\ *)
        # Split words without eval or pathname expansion. Accept two hashes only.
        set -f
        set -- $SSH_ORIGINAL_COMMAND
        test "$#" = 3
        for hash in "$2" "$3"; do
            test "${#hash}" = 64
            case "$hash" in *[!0-9a-f]*) exit 1;; esac
        done
        test "$(cat /etc/mango-ha-update-install-enabled 2>/dev/null)" = enabled
        exec 7> /var/lock/mango-ha-update-request.lock
        flock -n 7
        exec 9> /var/lock/mango-ha-update-job.lock
        flock -n 9
        test "$(cat "$state/state")" = READY
        test "$2" = "$(cat "$state/sha256")"
        printf '%s\n' "$2" > "$state/request-image-sha256"
        printf '%s\n' "$3" > "$state/request-backup-sha256"
        printf '%s\n' install > "$state/mode"
        printf '%s\n' INSTALL_QUEUED > "$state/state"
        flock -u 9
        exec 9>&-
        /etc/init.d/mango-ha-update-job stop 7>&- >/dev/null 2>&1 || true
        if ! /etc/init.d/mango-ha-update-job start 7>&-; then
            printf '%s\n' ERROR > "$state/state"
            exit 1
        fi
        echo 'STATE=INSTALL_QUEUED'
        ;;
    job)
        current=$(cat "$state/state" 2>/dev/null || printf IDLE)
        printf 'STATE=%s\n' "$current"
        printf 'VERSION=%s\n' "$(cat /lib/gluon/release)"
        printf 'BOOT_ID=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        case "$current" in READY|INSTALL_QUEUED|INSTALLING)
            printf 'SHA256=%s\n' "$(cat "$state/sha256")"
        ;; esac
        enabled=0
        if test "$(cat /etc/mango-ha-update-install-enabled 2>/dev/null)" = enabled; then enabled=1; fi
        printf 'INSTALL_ENABLED=%s\n' "$enabled"
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
            QUEUED|PREPARING|READY|INSTALL_QUEUED|INSTALLING) echo 'Background job already present.' >&2; exit 1;;
        esac
        /usr/sbin/autoupdater --branch mango --force --no-action 9>&-
        ;;
    *)
        echo 'Allowed commands: status, health, check, prepare, job and gated install IMAGE_SHA256 BACKUP_SHA256.' >&2
        exit 1
        ;;
esac
LOCKFIX_2
/bin/sh -n "$work/dispatch.sh"
save=$(mktemp -d /root/vor-ha-lockfix.XXXXXX)
cp -p "/etc/mango-ha-update-worker.sh" "$save/worker.sh"
cp -p "/etc/mango-ha-update-install.sh" "$save/install.sh"
cp -p "/etc/mango-ha-update.sh" "$save/dispatch.sh"
echo "Sicherung: $save"
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
cp "$work/worker.sh" "/etc/mango-ha-update-worker.sh.new"
chmod 700 "/etc/mango-ha-update-worker.sh.new"
mv "/etc/mango-ha-update-worker.sh.new" "/etc/mango-ha-update-worker.sh"
cp "$work/install.sh" "/etc/mango-ha-update-install.sh.new"
chmod 700 "/etc/mango-ha-update-install.sh.new"
mv "/etc/mango-ha-update-install.sh.new" "/etc/mango-ha-update-install.sh"
cp "$work/dispatch.sh" "/etc/mango-ha-update.sh.new"
chmod 700 "/etc/mango-ha-update.sh.new"
mv "/etc/mango-ha-update.sh.new" "/etc/mango-ha-update.sh"
flock -u 9
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
