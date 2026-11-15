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
        /etc/init.d/mango-ha-update-job stop >/dev/null 2>&1 || true
        if ! /etc/init.d/mango-ha-update-job start; then
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
        /etc/init.d/mango-ha-update-job stop >/dev/null 2>&1 || true
        if ! /etc/init.d/mango-ha-update-job start; then
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
        /usr/sbin/autoupdater --branch mango --force --no-action
        ;;
    *)
        echo 'Allowed commands: status, health, check, prepare, job and gated install IMAGE_SHA256 BACKUP_SHA256.' >&2
        exit 1
        ;;
esac
