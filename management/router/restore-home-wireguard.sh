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
