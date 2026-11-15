from pathlib import Path
import hashlib
root=Path(__file__).resolve().parent
files=root.parent/'packages/mango-management/files'
paths=['usr/sbin/mango-management-refresh','usr/sbin/mango-management-restore','lib/gluon/upgrade/997-mango-management-network']
old=(root/'mobile-original-refresh.sha256').read_text().strip()
s='''#!/bin/sh
# Backport for the enrolled Mango 02 on test7. Does not flash or restart networking.
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhal9483c41b9b72
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get mango_management.main.enabled)" = 1
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.3/32
test "$(uci -q get network.wgverwaltung.tunlink)" = wan
test "$(uci -q get firewall.wgverwaltung.input)" = DROP
test "$(uci -q get firewall.wgverwaltung.forward)" = DROP
test ! -e /usr/sbin/mango-management-restore
test ! -e /lib/gluon/upgrade/997-mango-management-network
test -f /etc/sysupgrade.conf
for config in network firewall mango_management; do
    test -z "$(uci changes "$config")"
done
command -v timeout >/dev/null
command -v jsonfilter >/dev/null
command -v iptables >/dev/null
command -v ip6tables >/dev/null
'''
s+=f"echo '{old}  /usr/sbin/mango-management-refresh' | sha256sum -c -\n"
s+='''# Use the same lock as cron/hotplug while replacing scripts.
lock=/tmp/mango-management-refresh.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Adresspruefung gerade aktiv. Noch nichts geaendert; nach 20 Sekunden erneut ausfuehren.' >&2
    exit 1
fi
work=$(mktemp -d /tmp/mango-mobile-fix.XXXXXX)
installed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$installed" = 1; then
        uci revert firewall || true
        cp -p "$save/firewall" /etc/config/firewall
        cp -p "$save/refresh" /usr/sbin/mango-management-refresh
        cp -p "$save/sysupgrade.conf" /etc/sysupgrade.conf
        rm -f /usr/sbin/mango-management-restore /lib/gluon/upgrade/997-mango-management-network
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo 'FEHLER: Vorherige Skripte und Firewall wiederhergestellt.' >&2
    fi
    rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
'''
for i,path in enumerate(paths):
 content=(files/path).read_text()
 s+=f"cat > \"$work/file{i}\" <<'MANGO_FILE_{i}'\n{content}MANGO_FILE_{i}\n"
 s+=f"sh -n \"$work/file{i}\"\n"
s+='''save=$(mktemp -d /root/vor-mango-mobile-fix.XXXXXX)
cp -p /etc/config/firewall "$save/firewall"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
cp -p /usr/sbin/mango-management-refresh "$save/refresh"
echo "Lokale Ruecknahme-Sicherung: $save"
installed=1
'''
for i,path in enumerate(paths):
 s+=f'cp "$work/file{i}" /{path}\nchmod 700 /{path}\n'
 s+=f"grep -Fxq '/{path}' /etc/sysupgrade.conf || printf '%s\\n' '/{path}' >> /etc/sysupgrade.conf\n"
s+='''echo '--- Upgrade-Wiederherstellung auf vorhandener Konfiguration pruefen ---'
network_before=$(sha256sum /etc/config/network)
/usr/sbin/mango-management-restore
test "$network_before" = "$(sha256sum /etc/config/network)"
# Keep the production lock while running the same refresh logic with a private
# lock directory for this one installer invocation. Cron remains excluded.
sed "s|lock=/tmp/mango-management-refresh.lock|lock=$work/refresh-lock|" \\
    /usr/sbin/mango-management-refresh > "$work/refresh-test"
echo '--- Aktuelle Gateway-Adressen und DNS pruefen ---'
sh "$work/refresh-test"
echo '--- Alle konfigurierten Sperradressen und Ports in der Firewall pruefen ---'
zone=$(uci -q get mango_management.main.uplink_zone)
for family in 4 6; do
    tool=iptables
    test "$family" = 4 || tool=ip6tables
    for address in $(uci -q get firewall.mango_fritz_v$family.dest_ip); do
        for port in 80 443 49000 49443; do
            "$tool" -C "zone_${zone}_output" -d "$address" -p tcp -m tcp --dport "$port" \\
                -m comment --comment "!fw3: Mango-Fritz-v$family" -j "zone_${zone}_dest_REJECT"
        done
    done
done
wg show wgverwaltung
ip -4 route get 172.27.66.1
echo 'ERFOLG: Standort-Adresserkennung und Upgrade-Wiederherstellung korrigiert.'
echo 'Kein Firmware-Flash und kein Netzwerk-Neustart ausgefuehrt.'
echo 'Neustarttest und Test am Anschluss des Vaters stehen noch aus.'
'''
(root/'install-router-mobile-fix.sh').write_text(s)
print(hashlib.sha256(s.encode()).hexdigest())
