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
