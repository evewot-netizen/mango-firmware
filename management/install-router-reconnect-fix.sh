#!/bin/sh
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhal9483c41b9b72
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get mango_management.main.enabled)" = 1
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.3/32
test "$(uci -q get network.wgverwaltung.tunlink)" = wan
test -f /etc/crontabs/root
test -f /etc/sysupgrade.conf
test ! -e /usr/sbin/mango-management-reconnect
for tool in timeout jsonfilter nslookup ubus; do command -v "$tool" >/dev/null; done
work=$(mktemp -d /tmp/mango-reconnect-install.XXXXXX)
changed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$changed" = 1; then
        cp -p "$save/crontab" /etc/crontabs/root
        cp -p "$save/sysupgrade.conf" /etc/sysupgrade.conf
        rm -f /usr/sbin/mango-management-reconnect
        /etc/init.d/cron restart || true
        echo 'Installation zurueckgenommen.' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/reconnect" <<'MANGO_RECONNECT'
#!/bin/sh
# Retry only the observed NO_DEVICE startup failure; never restart a healthy peer.
set -eu
umask 077
. /usr/lib/mango-management/common.sh
test "$(get enabled || true)" = 1 || exit 0
test "$(uci -q get network.wgverwaltung.proto)" = wireguard || exit 1
test "$(uci -q get network.wgverwaltung.auto)" = 1 || exit 0
uplink=$(get uplink_interface)
case "$uplink" in ''|*[!A-Za-z0-9_]*) exit 1;; esac
test "$(uci -q get network.wgverwaltung.tunlink)" = "$uplink" || exit 1
endpoint=$(uci -q get network.wgverwaltung_pi.endpoint_host)
hostname "$endpoint" || exit 1
lock=/tmp/mango-management-reconnect.lock
mkdir "$lock" 2>/dev/null || exit 0
trap 'rm -rf "$lock"' EXIT
trap 'exit 1' HUP INT TERM
ifstatus wgverwaltung > "$lock/tunnel" || exit 1
field() { jsonfilter -i "$lock/tunnel" -e "@.$1"; }
test "$(field up)" = false || exit 0
test "$(field pending)" = false || exit 0
test "$(field autostart)" = true || exit 0
jsonfilter -i "$lock/tunnel" -e '@.errors[*].code' | grep -Fxq NO_DEVICE || exit 0
ifstatus "$uplink" > "$lock/uplink" || exit 1
test "$(jsonfilter -i "$lock/uplink" -e '@.up')" = true || exit 0
# Keep the configured hostname for future address changes. No pinned public IP.
timeout 20 nslookup "$endpoint" > "$lock/dns" 2>&1 || exit 0
awk '/^Name:/ {answer=1; next} answer && /^Address([[:space:]]|:)/ {found=1} END {exit !found}' "$lock/dns" || exit 0
# Re-read immediately before mutation; another start may have completed meanwhile.
ifstatus wgverwaltung > "$lock/tunnel" || exit 1
test "$(field up)" = false || exit 0
test "$(field pending)" = false || exit 0
test "$(field autostart)" = true || exit 0
jsonfilter -i "$lock/tunnel" -e '@.errors[*].code' | grep -Fxq NO_DEVICE || exit 0
ubus call network.interface.wgverwaltung notify_proto '{"action":5,"available":true}'
# action 5 already causes netifd to reevaluate autostart. Avoid a second ifup race.
logger -t mango-management 'WireGuard-Start nach NO_DEVICE und erfolgreicher DNS-Pruefung erneut freigegeben.'
MANGO_RECONNECT
sh -n "$work/reconnect"
save=$(mktemp -d /root/vor-mango-reconnect.XXXXXX)
cp -p /etc/crontabs/root "$save/crontab"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/reconnect" /usr/sbin/mango-management-reconnect
chmod 700 /usr/sbin/mango-management-reconnect
/usr/sbin/mango-management-reconnect
job='* * * * * /usr/sbin/mango-management-reconnect >/dev/null 2>&1'
grep -Fxq "$job" /etc/crontabs/root || printf '\n%s\n' "$job" >> /etc/crontabs/root
for path in /usr/sbin/mango-management-reconnect /etc/crontabs/root; do
    grep -Fxq "$path" /etc/sysupgrade.conf || printf '%s\n' "$path" >> /etc/sysupgrade.conf
done
/etc/init.d/cron enable
/etc/init.d/cron restart
echo 'ERFOLG: Automatische Wiederaufnahme einmal pro Minute eingerichtet.'
echo 'Kein Router-Neustart ausgefuehrt. Neustarttest steht noch aus.'
