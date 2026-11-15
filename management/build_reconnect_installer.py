from pathlib import Path
import hashlib
r=Path(__file__).resolve().parent.parent
f=r/'packages/mango-management/files'
line="job='* * * * * /usr/sbin/mango-management-reconnect >/dev/null 2>&1'\ngrep -Fxq \"$job\" /etc/crontabs/root || printf '\\n%s\\n' \"$job\" >> /etc/crontabs/root\n"
s='''#!/bin/sh
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
'''+(f/'usr/sbin/mango-management-reconnect').read_text()+'''MANGO_RECONNECT
sh -n "$work/reconnect"
save=$(mktemp -d /root/vor-mango-reconnect.XXXXXX)
cp -p /etc/crontabs/root "$save/crontab"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/reconnect" /usr/sbin/mango-management-reconnect
chmod 700 /usr/sbin/mango-management-reconnect
/usr/sbin/mango-management-reconnect
'''+line+'''for path in /usr/sbin/mango-management-reconnect /etc/crontabs/root; do
    grep -Fxq "$path" /etc/sysupgrade.conf || printf '%s\\n' "$path" >> /etc/sysupgrade.conf
done
/etc/init.d/cron enable
/etc/init.d/cron restart
echo 'ERFOLG: Automatische Wiederaufnahme einmal pro Minute eingerichtet.'
echo 'Kein Router-Neustart ausgefuehrt. Neustarttest steht noch aus.'
'''
(r/'management/install-router-reconnect-fix.sh').write_text(s)
print(hashlib.sha256(s.encode()).hexdigest())
