from pathlib import Path

root = Path(__file__).resolve().parent
s = '''#!/bin/sh
set -eu
umask 077
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(cat /proc/sys/kernel/random/boot_id)" = 93af7b15-3f87-4041-ba1c-d65f806927e8
test -z "$(uci changes network)"
test -z "$(uci changes firewall)"
test -z "$(uci -q get network.wgverwaltung || true)"
test -z "$(uci -q get network.wgverwaltung_pi || true)"
test ! -e /etc/mango-ha-restore-wireguard.sh
test ! -e /lib/gluon/upgrade/997-mango-ha-wireguard
test "$(wg pubkey < /etc/wireguard/mango-management.key)" = 'SmviIyXKGp6LeiQe7xE4aTZNBF6xRz7iXK3LNMedUD0='
echo '--- Vorhandene Verwaltungs-Firewall ---'
uci show firewall | grep -E "wgverwaltung|wgmgmt|mango_fritz" || true
# The interface must join its existing, closed management zone.
uci show firewall | grep -Eq "\\.name='wgmgmt'$" || {
    echo 'Verwaltungszone fehlt. Abbruch vor Aenderungen.' >&2
    exit 1
}
work=$(mktemp -d /tmp/mango-wg-restore.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/restore.sh" <<'MANGO_RESTORE'
'''
s += (root/'router/restore-home-wireguard.sh').read_text()
s += '''MANGO_RESTORE
cat > "$work/hook" <<'MANGO_HOOK'
#!/bin/sh
# Local Mango Zuhause configuration, restored before Gluon's 998-commit.
exec /bin/sh /etc/mango-ha-restore-wireguard.sh
MANGO_HOOK
/bin/sh -n "$work/restore.sh"
/bin/sh -n "$work/hook"
save=$(mktemp -d /root/vor-ha-wg-restore.XXXXXX)
cp -p /etc/config/network "$save/network"
cp -p /etc/config/firewall "$save/firewall"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
echo "Sicherung: $save"
cp "$work/restore.sh" /etc/mango-ha-restore-wireguard.sh
chmod 700 /etc/mango-ha-restore-wireguard.sh
cp "$work/hook" /lib/gluon/upgrade/997-mango-ha-wireguard
chmod 700 /lib/gluon/upgrade/997-mango-ha-wireguard
for file in /etc/mango-ha-restore-wireguard.sh /lib/gluon/upgrade/997-mango-ha-wireguard /etc/wireguard/mango-management.key; do
    grep -Fxq "$file" /etc/sysupgrade.conf || printf '%s\\n' "$file" >> /etc/sysupgrade.conf
done
echo '--- Verwaltungstunnel wiederherstellen ---'
if ! /bin/sh /etc/mango-ha-restore-wireguard.sh; then
    uci revert network
    cp -p "$save/network" /etc/config/network
    cp -p "$save/sysupgrade.conf" /etc/sysupgrade.conf
    rm -f /etc/mango-ha-restore-wireguard.sh /lib/gluon/upgrade/997-mango-ha-wireguard
    echo 'Abbruch: vorherige Konfiguration wiederhergestellt.' >&2
    exit 1
fi
echo '--- Upgrade-Schritt ohne weitere Aenderung testen ---'
/lib/gluon/upgrade/997-mango-ha-wireguard
ubus call network reload
ifup wgverwaltung
/etc/init.d/firewall reload
echo '--- Bis zu 30 Sekunden auf Handshake warten ---'
for attempt in 1 2 3 4 5 6; do
    sleep 5
    handshake=$(wg show wgverwaltung latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')
    if test "${handshake:-0}" -gt 0; then break; fi
done
echo '--- Verwaltungstunnel ---'
wg show wgverwaltung
ip -4 route get 192.168.178.38
ip -4 route get 172.27.66.1
echo '--- Freifunk-VPN ---'
SSH_ORIGINAL_COMMAND=vpn /bin/sh /etc/mango-ha-monitor.sh
echo '--- Verbindung und Schutzregeln ---'
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
echo 'ERFOLG: WireGuard wiederhergestellt und Upgrade-Schritt eingerichtet.'
'''
(root/'install-router-restore-wireguard.sh').write_text(s)
