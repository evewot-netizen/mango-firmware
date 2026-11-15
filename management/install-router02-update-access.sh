#!/bin/sh
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
test ! -e /etc/mango-ha-backup.sh
test ! -e /etc/mango-ha-update.sh
test ! -e /etc/mango-ha-update-worker.sh
test ! -e /etc/mango-ha-update-install.sh
test ! -e /etc/init.d/mango-ha-update-job
test ! -e /etc/mango-ha-update-install-enabled
if grep -Eq 'ha-mango-02-(backup|update)|ICKpsXrM9TrWyp38sI5wctJYaj12rCn9StZEC7sXHRhM|IL8eq56t3IAeqiJJ9baW9LNRwUldUbxHCkqEKBLQqnWD' /etc/dropbear/authorized_keys; then
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
        rm -f /etc/mango-ha-backup.sh
        rm -f /etc/mango-ha-update.sh
        rm -f /etc/mango-ha-update-worker.sh
        rm -f /etc/mango-ha-update-install.sh
        rm -f /etc/init.d/mango-ha-update-job
        rm -f /etc/mango-ha-update-install-enabled
        echo 'FEHLER: Neue Update-Zugaenge wieder entfernt.' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/file0" <<'MANGO_FILE_0'
#!/bin/sh
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
MANGO_FILE_0
sh -n "$work/file0"
cat > "$work/file1" <<'MANGO_FILE_1'
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
        test -x /usr/sbin/mango-management-refresh || health_fail 'Adresspruefung fehlt'
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
MANGO_FILE_1
sh -n "$work/file1"
cat > "$work/file2" <<'MANGO_FILE_2'
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
MANGO_FILE_2
sh -n "$work/file2"
cat > "$work/file3" <<'MANGO_FILE_3'
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
MANGO_FILE_3
sh -n "$work/file3"
cat > "$work/file4" <<'MANGO_FILE_4'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
    mode=$(cat /tmp/mango-ha-update-job/mode 2>/dev/null || printf prepare)
    case "$mode" in
        prepare) worker=/etc/mango-ha-update-worker.sh;;
        install) worker=/etc/mango-ha-update-install.sh;;
        *) return 1;;
    esac
    procd_open_instance
    procd_set_param command /bin/sh "$worker"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
MANGO_FILE_4
sh -n "$work/file4"
cat > "$work/file5" <<'MANGO_FILE_5'
enabled
MANGO_FILE_5
save=$(mktemp -d /root/vor-mango02-update-setup.XXXXXX)
cp -p /etc/dropbear/authorized_keys "$save/authorized_keys"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/file0" /etc/mango-ha-backup.sh
chmod 700 /etc/mango-ha-backup.sh
cp "$work/file1" /etc/mango-ha-update.sh
chmod 700 /etc/mango-ha-update.sh
cp "$work/file2" /etc/mango-ha-update-worker.sh
chmod 700 /etc/mango-ha-update-worker.sh
cp "$work/file3" /etc/mango-ha-update-install.sh
chmod 700 /etc/mango-ha-update-install.sh
cp "$work/file4" /etc/init.d/mango-ha-update-job
chmod 700 /etc/init.d/mango-ha-update-job
cp "$work/file5" /etc/mango-ha-update-install-enabled
chmod 700 /etc/mango-ha-update-install-enabled
grep -Fxq '/etc/mango-ha-backup.sh' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-backup.sh' >> /etc/sysupgrade.conf
grep -Fxq '/etc/mango-ha-update.sh' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-update.sh' >> /etc/sysupgrade.conf
grep -Fxq '/etc/mango-ha-update-worker.sh' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-update-worker.sh' >> /etc/sysupgrade.conf
grep -Fxq '/etc/mango-ha-update-install.sh' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-update-install.sh' >> /etc/sysupgrade.conf
grep -Fxq '/etc/init.d/mango-ha-update-job' /etc/sysupgrade.conf || printf '%s\n' '/etc/init.d/mango-ha-update-job' >> /etc/sysupgrade.conf
grep -Fxq '/etc/mango-ha-update-install-enabled' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-update-install-enabled' >> /etc/sysupgrade.conf
grep -Fxq '/etc/dropbear/authorized_keys' /etc/sysupgrade.conf || printf '%s\n' '/etc/dropbear/authorized_keys' >> /etc/sysupgrade.conf
grep -Fxq '/etc/mango-ha-update-last' /etc/sysupgrade.conf || printf '%s\n' '/etc/mango-ha-update-last' >> /etc/sysupgrade.conf
grep -Fxq '/usr/sbin/mango-management-refresh' /etc/sysupgrade.conf || printf '%s\n' '/usr/sbin/mango-management-refresh' >> /etc/sysupgrade.conf
grep -Fxq '/usr/sbin/mango-management-restore' /etc/sysupgrade.conf || printf '%s\n' '/usr/sbin/mango-management-restore' >> /etc/sysupgrade.conf
grep -Fxq '/usr/sbin/mango-management-reconnect' /etc/sysupgrade.conf || printf '%s\n' '/usr/sbin/mango-management-reconnect' >> /etc/sysupgrade.conf
grep -Fxq '/lib/gluon/upgrade/997-mango-management-network' /etc/sysupgrade.conf || printf '%s\n' '/lib/gluon/upgrade/997-mango-management-network' >> /etc/sysupgrade.conf
grep -Fxq '/etc/crontabs/root' /etc/sysupgrade.conf || printf '%s\n' '/etc/crontabs/root' >> /etc/sysupgrade.conf
printf '\n' >> /etc/dropbear/authorized_keys
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
grep -Fxq 'etc/mango-ha-backup.sh' "$work/contents"
grep -Fxq 'etc/mango-ha-update.sh' "$work/contents"
grep -Fxq 'etc/mango-ha-update-worker.sh' "$work/contents"
grep -Fxq 'etc/mango-ha-update-install.sh' "$work/contents"
grep -Fxq 'etc/init.d/mango-ha-update-job' "$work/contents"
grep -Fxq 'etc/mango-ha-update-install-enabled' "$work/contents"
echo 'ERFOLG: Eingeschraenkter Backup- und Update-Zugang fuer Mango 02 eingerichtet.'
echo 'Keine Firmware-Pruefung, Installation oder Zeitplanung gestartet.'
