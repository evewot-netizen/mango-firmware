from pathlib import Path
import hashlib
root=Path(__file__).resolve().parent
files=root.parent/'packages/mango-management/files'
common=(files/'usr/lib/mango-management/common.sh').read_text()
helpers=common[common.index('fail()'):common.index('validate_profile()')]
s=(files/'usr/sbin/mango-management-refresh').read_text()
s=s.replace('. /usr/lib/mango-management/common.sh\ntest "$(get enabled || true)" = 1 || exit 0',helpers.rstrip())
s=s.replace('uplink=$(get uplink_interface)','uplink=wan').replace('zone=$(get uplink_zone)','zone=wan').replace('name=$(get gateway_dns_name)','name=fritz.box')
s=s.replace('/tmp/mango-management-refresh.lock','/tmp/mango-fritz-adressen.lock').replace('/tmp/mango-management-last-check','/tmp/mango-fritz-last-check').replace('-t mango-management','-t mango-fritz')
(root/'router/fritz-addresses.sh').write_text(s)
old=(root/'home-original-addresses.sha256').read_text().strip()
installer='''#!/bin/sh
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhale4956e45c3b1
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.2/32
test "$(uci -q get firewall.wgverwaltung.input)" = DROP
test "$(uci -q get firewall.wgverwaltung.forward)" = DROP
test -z "$(uci changes firewall)"
for tool in timeout jsonfilter iptables ip6tables; do command -v "$tool" >/dev/null; done
grep -Fxq /etc/mango-fritz-adressen.sh /etc/sysupgrade.conf
grep -Fq '/etc/mango-fritz-adressen.sh' /etc/crontabs/root
'''+f"echo '{old}  /etc/mango-fritz-adressen.sh' | sha256sum -c -\n"+'''
lock=/tmp/mango-fritz-adressen.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Adresspruefung gerade aktiv. Noch nichts geaendert; nach 20 Sekunden erneut versuchen.' >&2
    exit 1
fi
work=$(mktemp -d /tmp/mango-home-guard.XXXXXX)
changed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$changed" = 1; then
        uci revert firewall || true
        cp -p "$save/firewall" /etc/config/firewall
        cp -p "$save/adressen.sh" /etc/mango-fritz-adressen.sh
        if /etc/init.d/firewall reload >/dev/null 2>&1; then
            echo 'FEHLER: Vorheriges Skript und Firewall wiederhergestellt.' >&2
        else
            echo 'FEHLER: Ruecknahme gespeichert, Firewall-Neuladen fehlgeschlagen.' >&2
        fi
    fi
    rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/adressen.sh" <<'MANGO_HOME_GUARD'
'''+s+'''MANGO_HOME_GUARD
sh -n "$work/adressen.sh"
save=$(mktemp -d /root/vor-mango-home-guard.XXXXXX)
cp -p /etc/config/firewall "$save/firewall"
cp -p /etc/mango-fritz-adressen.sh "$save/adressen.sh"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/adressen.sh" /etc/mango-fritz-adressen.sh
chmod 700 /etc/mango-fritz-adressen.sh
# Keep the production lock held against cron/hotplug while checking the new logic.
sed "s|lock=/tmp/mango-fritz-adressen.lock|lock=$work/check-lock|" \\
    /etc/mango-fritz-adressen.sh > "$work/check"
echo '--- Gateway- und DNS-Adresserkennung pruefen ---'
sh "$work/check"
echo '--- Aktive Sperren fuer alle Adressen und Ports pruefen ---'
for family in 4 6; do
    tool=iptables
    test "$family" = 4 || tool=ip6tables
    for address in $(uci -q get firewall.mango_fritz_v$family.dest_ip); do
        for port in 80 443 49000 49443; do
            "$tool" -C zone_wan_output -d "$address" -p tcp -m tcp --dport "$port" \\
                -m comment --comment "!fw3: Mango-Fritz-v$family" -j zone_wan_dest_REJECT
        done
    done
done
echo '--- Verwaltung und Freifunk pruefen ---'
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
SSH_ORIGINAL_COMMAND=vpn /bin/sh /etc/mango-ha-monitor.sh
wg show wgverwaltung
echo 'ERFOLG: Schutz-Adresserkennung fuer Mango Zuhause aktualisiert.'
echo 'Kein Firmware-Flash und kein Netzwerk-Neustart ausgefuehrt.'
'''
(root/'install-router-home-guard.sh').write_text(installer)
print(hashlib.sha256(installer.encode()).hexdigest())
