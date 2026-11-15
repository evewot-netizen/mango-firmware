#!/bin/sh
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
uci show firewall | grep -Eq "\.name='wgmgmt'$" || {
    echo 'Verwaltungszone fehlt. Abbruch vor Aenderungen.' >&2
    exit 1
}
work=$(mktemp -d /tmp/mango-wg-restore.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/restore.sh" <<'MANGO_RESTORE'
#!/bin/sh
# Explicitly installed ONLY on Mango Zuhause, never included in generic firmware.
# Gluon 001-reset-uci rebuilds network; hook 997 restores this private tunnel.
set -eu
umask 077
fail() { echo "Mango Zuhause WireGuard: $*" >&2; exit 1; }
key=/etc/wireguard/mango-management.key
client_public='SmviIyXKGp6LeiQe7xE4aTZNBF6xRz7iXK3LNMedUD0='
server_public='bwTCbEG3jZQmjw/J4ydihVu0CGvXhe/4m5QAaBJc4mw='
test -s "$key" || fail 'Schluesseldatei fehlt.'
test "$(wg pubkey < "$key")" = "$client_public" || fail 'Schluessel gehoert nicht zu Mango Zuhause.'
test "$(uci -q get network.wan)" = interface || fail 'Heimnetz-Uplink wan fehlt.'
test -f /lib/netifd/proto/wireguard.sh || fail 'WireGuard-Unterstuetzung fehlt.'
iface=$(uci -q get network.wgverwaltung || true)
peer=$(uci -q get network.wgverwaltung_pi || true)
if test -n "$iface" || test -n "$peer"; then
    # Keep existing configuration; never silently replace partial/custom setup.
    test "$iface" = interface && test "$peer" = wireguard_wgverwaltung || fail 'Unvollstaendige vorhandene Einrichtung.'
    test "$(uci -q get network.wgverwaltung.proto)" = wireguard || fail 'Protokoll weicht ab.'
    test "$(uci -q get network.wgverwaltung.tunlink)" = wan || fail 'Uplink weicht ab.'
    test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.2/32 || fail 'Tunneladresse weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.public_key)" = "$server_public" || fail 'Server-Schluessel weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.endpoint_host)" = 192.168.178.38 || fail 'Endpoint weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.endpoint_port)" = 51820 || fail 'Endpoint-Port weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.allowed_ips)" = 172.27.66.1/32 || fail 'Server-Tunneladresse weicht ab.'
    test "$(uci -q get network.wgverwaltung.private_key)" = "$(cat "$key")" || fail 'Privater Schluessel weicht ab.'
    echo 'Mango Zuhause: vorhandene WireGuard-Konfiguration bestaetigt.'
    exit 0
fi
uci batch <<'NETWORK'
set network.wgverwaltung=interface
set network.wgverwaltung.proto=wireguard
set network.wgverwaltung.auto=1
set network.wgverwaltung.mtu=1420
set network.wgverwaltung.tunlink=wan
add_list network.wgverwaltung.addresses=172.27.66.2/32
set network.wgverwaltung_pi=wireguard_wgverwaltung
set network.wgverwaltung_pi.public_key='bwTCbEG3jZQmjw/J4ydihVu0CGvXhe/4m5QAaBJc4mw='
set network.wgverwaltung_pi.endpoint_host=192.168.178.38
set network.wgverwaltung_pi.endpoint_port=51820
set network.wgverwaltung_pi.persistent_keepalive=25
set network.wgverwaltung_pi.route_allowed_ips=1
add_list network.wgverwaltung_pi.allowed_ips=172.27.66.1/32
NETWORK
uci set "network.wgverwaltung.private_key=$(cat "$key")"
uci commit network
chmod 600 /etc/config/network
echo 'Mango Zuhause: WireGuard-Konfiguration mit Uplink wan wiederhergestellt.'
MANGO_RESTORE
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
    grep -Fxq "$file" /etc/sysupgrade.conf || printf '%s\n' "$file" >> /etc/sysupgrade.conf
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
